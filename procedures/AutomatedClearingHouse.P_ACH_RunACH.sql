--liquibase formatted sql

--changeset  Zaher:e0l12dc1-b0e1-45a4-ae00-23e189838111 stripComments:false runOnChange:true splitStatements:false
/*
Author: Zaher Al Sabbagh
Version: 1.0
Created Date: 2012/02/19
Reason:
Sample call:
begin tran
declare
	@AccountCount      int     ,
     @BatchNum          int,
     @ErrorCode			INT,
     @ErrorMsg			VARCHAR(max)
EXEC [AutomatedClearingHouse].[P_ACH_RunACH_optimized] @DateDue = '2016-04-21', @AdminName = 1160, @IP = '192.168.151.112',
	@AccountCount = @AccountCount OUTPUT, @BatchNum = @BatchNum OUTPUT, @ErrorCode = @ErrorCode OUTPUT, @ErrorMsg = @ErrorMsg OUTPUT
rollback

Frequency: onec a day
CH 20150517: optimization remove cursor
CH 20160517: add a missing join resulting in a cartesian product
CH 20160517: change the isolation level to readuncommitted
JL 20171215: added ordertype 68
JL 20191204: Support for tblOrderItemBilling
MR 20200501: added marketplace and branded shipping fee logic. Created table #preAccount. Summed this before adding into #Account
ZA 20200721: Support for new Post-paid consumer promotion order types
CH:20200219: Add dynamic filtered index Fix_OrderNo_LastDays and to use it add dynamic sql
MR 20211105: Added Multi Form Of Payment order types (released 02/16/2022)
MR 20211202: Excluded Account Balance product ID 15692 (released 02/16/2022)
ZA 20220217: SET @DateDue = CAST(@DateDue AS DATE)
MR 20220217: Swiched Account Balance ID to the Prod ProductID
MR 20220314: Added order type 35 (Fee)
ZA 20221018: update logic to stamped orders to exclude pending activations on promos
MR 20230329: Added separate sections for the credit card multi-form of payment order types 77 and 78 to verify that the
		   :	original handset order is filled before ACH'ing the credit card payment (order type 77),
		   :	and to verify that the original credit card order is filled before ACH'ing the refund (order type 78).
MR 20230330: Added DISTINCT to the previous day changes.
MR 20231004: Rearranged the MFOP logic to check for filled handsets tied to refund order type 78 before including 78 on the ACH.

*/
CREATE OR ALTER PROCEDURE [AutomatedClearingHouse].[P_ACH_RunACH]
    (
      @DateDue DATETIME ,
      @AdminName NVARCHAR(50) ,
      @IP NVARCHAR(20) ,
      @AccountCount INT OUTPUT ,
      @BatchNum INT OUTPUT ,
      @ErrorCode INT OUTPUT ,
      @ErrorMsg VARCHAR(MAX) OUTPUT

    )
AS

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @AccountID INT ,
        @AchTotal DECIMAL(9, 2) ,
        @DebitBatchNum INT ,
        @CreditBatchNum INT ,
        @CustomerID INT ,
        @shiptoID INT ,
        @UserID INT ,
        @CreditTermsID INT ,
        @DiscountClassID INT ,
        @acct_settlement_amt DECIMAL(9, 2) ,
        @Order_no INT ,
        @Btach INT ,
        @CurrentAv FLOAT ,
        @AvCredit FLOAT ,
        @AppCredit FLOAT ,
        @CollectionDelay INT ,
        @InvoiceDueDate DATETIME ,
        @ReportCount INT ,
        @DayOftheWeek INT;

	SET @DateDue = CAST(@DateDue AS DATE)

    SELECT  @ReportCount = COUNT(Report_Log_SK)
    FROM    dbo.Report_Log
    WHERE   Effective_Dt >= @DateDue
            AND Report_ID IN ( 11, 12 );

-- CREATE INDEX IX_ReportLog_EffectiveDt ON Report_Log (Effective_Dt, Report_Id) with (online = on, sort_in_tempdb = on)

    IF ( @ReportCount = 0 )
        SELECT  @AccountCount = COUNT(Order_No)
        FROM    dbo.Order_No
        WHERE   OrderType_ID = 5
                AND DateOrdered < @DateDue
                AND DateDue >= @DateDue
                AND Void = 0
                AND Filled = 1
                AND Process = 1;
    ELSE
        SET @AccountCount = 0;


    IF ( ISNUMERIC(@AccountCount) = 0 )
        SET @AccountCount = 0;

    SET @ErrorCode = 0;
    SET @ErrorMsg = 'Passed';

    SELECT  @BatchNum = BatchNumACH
    FROM    dbo.OrderSettings o;
-- create temporary tables
    CREATE TABLE #TmpOrderNo
        (
          OrderNo INT ,
          AccountId INT ,
          OrderId INT ,
          Price DECIMAL(9, 5) ,
          DiscAmount DECIMAL(9, 5)
        );
    CREATE TABLE #TmpOrderNoFilled
        (
          OrderNo INT ,
          AccountId INT ,
          OrderId INT ,
          Price DECIMAL(9, 5) ,
          DiscAmount DECIMAL(9, 5)
        );
    CREATE TABLE #Orders ( OrderId INT );
	CREATE TABLE #OrdersPreHandsetCheck
		(
			OrderId INT,
			OrderLinkingID VARCHAR(100)
		);

	CREATE TABLE #PreAccount
        (
          AccountId INT ,
          AchTotal DECIMAL(9, 2)
        );
    CREATE TABLE #Account
        (
          AccountId INT ,
          AchTotal DECIMAL(9, 2),
          PRIMARY KEY CLUSTERED ( AccountId )
        );
    CREATE TABLE #OrderNoSettlement
        (
          OrderNo INT ,
          AccSettlement DECIMAL(9, 2) ,
          AccountId INT ,
          Btach INT
        );
    CREATE TABLE #OrderNoToProcessBeforeHandsetCheck
        (
          OrderNo INT ,
          Processed TINYINT ,
          AdminCreditText NVARCHAR(50) ,
          Status VARCHAR(32) ,
		  OrderLinkingID VARCHAR(100)
        );

    CREATE TABLE #OrderNoToProcess
        (
          OrderNo INT ,
          Processed TINYINT ,
          AdminCreditText NVARCHAR(50) ,
          Status VARCHAR(32) ,
          PRIMARY KEY CLUSTERED ( Processed, OrderNo )
        );


	--DECLARE @DateDue DATETIME = '2021-02-15'
	DECLARE @DateOrdered DATETIME = DATEADD(DAY, -3, @DateDue)
	DECLARE @dateorderedstr VARCHAR(64) = CONVERT(VARCHAR(16),@DateOrdered,112)
	DECLARE @Stmt NVARCHAR(MAX) = ''
	SET @Stmt = '
				SELECT  o.Order_No ,
						o.Account_ID ,
						o1.ID ,
						CASE
						WHEN ISNULL(oib.Billable, 1) = 0 THEN
							0
						ELSE o1.Price END AS [Price],
						 CASE
						WHEN ISNULL(oib.Billable, 1) = 0 THEN
							0
						ELSE o1.DiscAmount END AS [DiscAmount]
				FROM    dbo.Order_No o --WITH ( INDEX =DateOrdered_idx )
						JOIN dbo.Orders o1 ON o1.Order_No = o.Order_No
						JOIN dbo.Account a ON o.Account_ID = a.Account_ID
						LEFT JOIN OrderManagment.tblOrderItemBilling oib
							ON oib.OrdersId = o1.ID
				WHERE   o.DateOrdered > '''+@dateorderedstr+'''
						AND o.OrderType_ID IN ( 1, 9 )
						AND o.Paid = 0
						AND o.Void = 0
						AND o.Process = 1
						AND o.Filled = 0
						AND ISNUMERIC(o1.SKU) = 1
						AND LEN(o1.SKU) > 5;
	'
	--print @stmt

    INSERT  INTO #TmpOrderNo
            ( OrderNo ,
              AccountId ,
              OrderId ,
              Price ,
              DiscAmount
            )
	EXEC sp_executeSql @Stmt
--cleaning up IN process orders tahthas a good pins
    UPDATE  pub
    SET     AvailableDailyCreditLimit_Amt = pub.AvailableDailyCreditLimit_Amt
            - ( o.Price - o.DiscAmount ) ,
            AvailableTotalCreditLimit_Amt = pub.AvailableTotalCreditLimit_Amt
            - ( o.Price - o.DiscAmount )
    FROM    dbo.Account pub
            JOIN #TmpOrderNo o ON pub.Account_ID = o.AccountId;

    UPDATE  dbo.Order_No
    SET     Filled = 1 ,
            Process = 1 ,
            Void = 0 ,
            DateFilled = GETDATE()
    FROM    dbo.Order_No o
    WHERE   EXISTS ( SELECT 1
                     FROM   #TmpOrderNo sub
                     WHERE  sub.OrderNo = o.Order_No );

	--clean up all filled only orders
	--DECLARE @DateDue DATETIME = '2021-02-15'
	--DECLARE @DateOrdered DATETIME = DATEADD(DAY, -3, @DateDue)
	--DECLARE @dateorderedstr VARCHAR(64) = CONVERT(VARCHAR(16),@DateOrdered,112)
	--DECLARE @Stmt NVARCHAR(MAX) = ''
	SET @Stmt = '
			   SELECT  o.Order_No ,
						o.Account_ID ,
						o1.ID ,
						CASE
						WHEN ISNULL(oib.Billable, 1) = 0 THEN
							0
						ELSE o1.Price END AS [Price],
						 CASE
						WHEN ISNULL(oib.Billable, 1) = 0 THEN
							0
						ELSE o1.DiscAmount END AS [DiscAmount]
				FROM    dbo.Order_No o --WITH ( INDEX =DateOrdered_idx )
						JOIN dbo.Orders o1 ON o1.Order_No = o.Order_No
						JOIN dbo.Account a ON o.Account_ID = a.Account_ID
						LEFT JOIN OrderManagment.tblOrderItemBilling oib
							ON oib.OrdersId = o1.ID
				WHERE   o.DateOrdered > '''+@dateorderedstr+'''
						AND o.OrderType_ID IN ( 1, 9 )
						AND o.Paid = 0
						AND o.Void = 0
						AND o.Process = 0
						AND o.Filled = 1
						AND ISNUMERIC(o1.SKU) = 1
						AND LEN(o1.SKU) > 5;
	'
	--print @stmt

    INSERT  INTO #TmpOrderNoFilled
            ( OrderNo ,
              AccountId ,
              OrderId ,
              Price ,
              DiscAmount
            )
	EXEC sp_executeSql @Stmt

    UPDATE  pub
    SET     AvailableDailyCreditLimit_Amt = pub.AvailableDailyCreditLimit_Amt
            - ( o.Price - o.DiscAmount ) ,
            AvailableTotalCreditLimit_Amt = pub.AvailableTotalCreditLimit_Amt
            - ( o.Price - o.DiscAmount )
    FROM    dbo.Account pub
            JOIN #TmpOrderNoFilled o ON pub.Account_ID = o.AccountId;

    UPDATE  dbo.Order_No
    SET     Filled = 1 ,
            Process = 1 ,
            Void = 0 ,
            OrderTotal = sub.OrderAmount
    FROM    dbo.Order_No o
            JOIN ( SELECT   OrderNo ,
                            SUM(Price - DiscAmount) OrderAmount
                   FROM     #TmpOrderNoFilled
                   GROUP BY OrderNo
                 ) sub ON o.Order_No = sub.OrderNo;

    UPDATE  dbo.OrderSettings
    SET     BatchNumACH = BatchNumACH + 2;

    SET @DebitBatchNum = @BatchNum + 2;
    SET @CreditBatchNum = @BatchNum + 1;

-- to avoid the large key lookup cost, I calculate the orders



    INSERT  INTO #Orders
            ( OrderId
            )
            SELECT  o1.ID
            FROM    dbo.Order_No o WITH ( READUNCOMMITTED )
                    JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON o.Order_No = o1.Order_No
            WHERE   o.OrderType_ID IN ( 1, 2, 3, 8, 22, 28, 31, 34, 40, 46, 49,
                                        51, 54, 57, 62 , 68,75, 35)
                    AND o.Filled = 1
                    AND o.Process = 1
                    AND o.Void = 0
                    AND o.Paid = 0
                    AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)
                    AND o1.Product_ID NOT IN ( SELECT   Product_ID
                                               FROM     dbo.Products
                                               WHERE    SKU = 'phone' )
                    AND o.Order_No = o1.Order_No
					--AND (o.DateOrdered < '2017-01-17 14:15' OR o.DateOrdered > '2017-01-17 16:00')

----------Credit card orders---- MR20230329

   INSERT INTO #OrdersPreHandsetCheck
   (
       OrderId,
       OrderLinkingID
   )

            SELECT  DISTINCT o1.ID,
					link.OrderNoLinkingId
            FROM    dbo.Order_No o WITH ( READUNCOMMITTED )
                    JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON o.Order_No = o1.Order_No
					JOIN orders.tblOrderLinking AS link ON link.OrderNo = o1.Order_No
            WHERE   o.OrderType_ID IN ( 77)
                    AND o.Filled = 1
                    AND o.Process = 1
                    AND o.Void = 0
                    AND o.Paid = 0
					AND o1.product_ID = 15693		--Purchase Credit Card
                    AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)

----------Refund credit card orders---- MR20230329
   INSERT INTO #OrdersPreHandsetCheck
   (
       OrderId,
       OrderLinkingID
   )

            SELECT  DISTINCT o1.ID,
				    link.OrderNoLinkingId
            FROM    dbo.Order_No o WITH ( READUNCOMMITTED )
                    JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON o.Order_No = o1.Order_No
					JOIN orders.tblOrderLinking AS link ON link.OrderNo = o1.Order_No
					JOIN orders.tblOrderLinking AS CreditCard ON CreditCard.OrderNoLinkingId = link.OrderNoLinkingId
						AND CreditCard.OrderLinkingTypeId = 1 --FundingSource
					JOIN dbo.order_no AS o2  WITH ( READUNCOMMITTED ) ON o2.Order_No = CreditCard.OrderNo
						AND o2.Filled = 1
						AND o2.Void = 0
						AND o2.Process = 1
						AND o2.OrderType_ID = 77 --original purchase credit card
            WHERE   o.OrderType_ID IN (78) --refund
                    AND o.Filled = 1
                    AND o.Process = 1
                    AND o.Void = 0
                    AND o.Paid = 0
					AND o1.product_ID = 15693		--Purchase Credit Card
                    AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)

--this section added to check the linked handset for both order type 78 and 77 rather than just 77. MR20231004
	INSERT INTO #Orders
	(
	    OrderId
	)

			SELECT DISTINCT p.OrderId
			FROM #OrdersPreHandsetCheck AS p
			WHERE EXISTS(SELECT 1 FROM Orders.tblOrderLinking AS link
							JOIN dbo.order_no AS o2  WITH ( READUNCOMMITTED )
								ON o2.Order_No = link.OrderNo
									AND o2.Filled = 1
									AND o2.Void = 0
									AND o2.Process = 1
									AND o2.OrderType_ID IN (49, 57)
						WHERE p.OrderLinkingID = link.OrderNoLinkingId
							AND link.OrderLinkingTypeId = 2) --checkout


--Promo orders tied to filled activations
    INSERT  INTO #Orders
            ( OrderId
            )
			SELECT o1.ID
			FROM dbo.Order_No o WITH(READUNCOMMITTED)
				JOIN dbo.Orders o1 WITH(READUNCOMMITTED)
			ON o1.Order_No = o.Order_No
				JOIN dbo.Order_No o2 WITH(READUNCOMMITTED)
			ON o.AuthNumber = CAST(o2.Order_No AS NVARCHAR(15))
			WHERE o.OrderType_ID IN (59,71)
			AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)
			AND o.Filled = 1 AND o.Process = 1 AND o.Void = 0 AND o.Paid = 0
			AND o2.Filled = 1 AND o2.Process = 1 AND o2.Void = 0

-- calculate ach total per account


    INSERT  INTO #PreAccount
            SELECT  a.Account_ID ,
                    SUM(a.total)
            FROM    ( SELECT    o.Account_ID ,
                                ROUND(SUM(CASE
								WHEN ISNULL(oib.Billable, 1) = 0 THEN
								    0
								WHEN o.OrderType_ID IN (77, 78) THEN		--MR20211105
								(o1.Price - o1.DiscAmount
                                          + isnull(o1.Fee,0)) * -1
								ELSE
								o1.Price - o1.DiscAmount
                                          + isnull(o1.Fee,0) END ), 2) [total]
                      FROM      #Orders tmp
                                JOIN dbo.Orders o1 WITH ( READUNCOMMITTED )     ON o1.ID = tmp.OrderId
                                JOIN dbo.Order_No o WITH ( READUNCOMMITTED )    ON o.Order_No = o1.Order_No
								LEFT JOIN OrderManagment.tblOrderItemBilling oib
									ON oib.OrdersId = o1.ID
                      GROUP BY  o.Account_ID
                      UNION ALL
                      SELECT    o.Account_ID ,
                                ROUND(SUM(CASE
								WHEN ISNULL(oib.Billable, 1) = 0 THEN
								    0
								ELSE o1.Price - o1.DiscAmount
                                          + ISNULL(o1.Fee,0) END ), 2) AS [total]
                      FROM      dbo.Order_No o
                                JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON o.Order_No = o1.Order_No
                                JOIN dbo.Account a ON o.Account_ID = a.Account_ID
								LEFT JOIN OrderManagment.tblOrderItemBilling oib
									ON oib.OrdersId = o1.ID
                      WHERE     o.OrderType_ID IN ( 21 )
                                AND a.AccountType_ID = 2
                                AND o.Filled = 1
                                AND o.Process = 1
                                AND o.Void = 0
                                AND o.Paid = 0
                                AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)
								AND (o.DateOrdered < '2017-01-17 14:15' OR o.DateOrdered > '2017-01-17 16:00')
                                AND o.Order_No = o1.Order_No
                      GROUP BY  o.Account_ID
                      HAVING    SUM(o1.Price - o1.DiscAmount) > 0
-- Add Shipping Cost
                      UNION ALL
                      SELECT    o.Account_ID ,
                                ROUND(SUM(o.Shipping), 2) [total]
                      FROM      dbo.Order_No o
                                JOIN dbo.Account a ON o.Account_ID = a.Account_ID
                      WHERE     o.OrderType_ID IN ( 21 )
                                AND a.AccountType_ID = 2
                                AND o.Filled = 1
                                AND o.Process = 1
                                AND o.Void = 0
                                AND o.Paid = 0
                                AND o.DateDue >= @DateDue AND o.DateDue < DATEADD(DAY,1,@DateDue)
								AND (o.DateOrdered < '2017-01-17 14:15' OR o.DateOrdered > '2017-01-17 16:00')
                      GROUP BY  o.Account_ID
                    ) AS a
                    JOIN dbo.Account a1 ON a1.Account_ID = a.Account_ID
            WHERE   ISNULL(a1.IstestAccount, 0) = 0
            GROUP BY a.Account_ID
 -- Add Marketplace and Branded Shipping Fees
					  UNION ALL
					  SELECT	t.Account_ID ,
								ROUND(SUM(t.Price), 2) [total]
					  FROM (SELECT DISTINCT n.account_id,
											bi.orderNO,
											bi.ShippingGroupId,
											bi.Price
							FROM #Orders AS d
								JOIN dbo.orders AS d2 WITH ( READUNCOMMITTED )  ON d2.id = d.OrderId
								JOIN dbo.order_no AS n WITH ( READUNCOMMITTED ) ON n.Order_No = d2.Order_No
								JOIN OrderManagment.tblOrderBillingItems AS bi	ON bi.OrderNo = n.Order_No
								AND bi.BillingItemTypeId = 1) AS t
					  GROUP BY t.Account_ID ;

	INSERT INTO #Account
	(
	    AccountId,
	    AchTotal
	)
	SELECT AccountId,
	       SUM(AchTotal) AS AchTotal
	FROM #PreAccount
	GROUP BY AccountId



    SELECT  A.AccountId ,
            A.AchTotal ,
            B.Customer_ID ,
            B.ShipTo ,
            B.User_ID ,
            B.CreditTerms_ID ,
            B.DiscountClass_ID ,
            B.AvailableTotalCreditLimit_Amt ,
            B.ApprovedTotalCreditLimit_Amt ,
            ISNULL(C.DaysDue_Num, 0) CollectionDelay ,
            InvoiceDueDate = CASE DATEPART(dw,
                                           DATEADD(DAY,
                                                   ISNULL(C.DaysDue_Num, 0),
                                                   @DateDue))
                               WHEN 7
                               THEN DATEADD(DAY, ISNULL(C.DaysDue_Num, 0) + 2,
                                            @DateDue)
                               WHEN 1
                               THEN DATEADD(DAY, ISNULL(C.DaysDue_Num, 0) + 1,
                                            @DateDue)
                               ELSE DATEADD(DAY, ISNULL(C.DaysDue_Num, 0),
                                            @DateDue)
                             END
    INTO    #AccountFinal
    FROM    #Account A
            JOIN dbo.Account B ON A.AccountId = B.Account_ID
            LEFT JOIN dbo.CreditTerms_ID C ON B.CreditTerms_ID = C.CreditTerms_ID;

    INSERT  INTO dbo.Order_No
            ( Filled ,
              Process ,
              Paid ,
              Void ,
              Account_ID ,
              Customer_ID ,
              ShipTo ,
              User_ID ,
              OrderType_ID ,
              Card_ID ,
              CreditTerms_ID ,
              DiscountClass_ID ,
              DateOrdered ,
              DateFilled ,
              DateDue ,
              OrderTotal ,
              Tax ,
              Shipping ,
              OrderDisc ,
              Credits ,
              AddonTotal ,
              Affiliate ,
              Admin_Updated ,
              Admin_Name ,
              AdminCredit ,
              Status ,
              User_IPAddress ,
              InvoiceNum
            )
    OUTPUT  Inserted.Order_No ,
            Inserted.OrderTotal ,
            Inserted.Account_ID
            INTO #OrderNoSettlement ( OrderNo, AccSettlement, AccountId )
            SELECT  1 ,
                    1 ,
                    1 ,
                    0 ,             -- Filled, Process, Paid, Void
                    AccountId ,             -- Account ID
                    Customer_ID ,            -- CustomerID
                    ShipTo ,              -- ShiptoID
                    User_ID ,                -- User ID
                    5 ,
                    2 ,                   -- Order Type, Card ID
                    CreditTerms_ID ,         -- Credit Terms ID
                    DiscountClass_ID ,       -- Discount Class ID
                    GETDATE() ,              -- Date Ordered
                    GETDATE() ,              -- Date Filled
                    InvoiceDueDate ,           -- Date Due
                    -1 * AchTotal AccSettlementAmount ,   -- OrderTotal
                    0 ,
                    0 ,
                    0 ,
                    0 ,
                    0 ,
                    1 ,       -- Tax, Shipping, OrderDisc, Credits, AddonTotal, Affiliate
                    GETDATE() ,
                    @AdminName ,
                    -1 * AchTotal ,
                    'ACH Payment ' + CAST(@CreditBatchNum AS VARCHAR(Max)) ,
                    @IP ,
                    @CreditBatchNum
            FROM    #AccountFinal;

    UPDATE  #OrderNoSettlement
    SET     Btach = CASE WHEN AccSettlement < 0 THEN @DebitBatchNum
                         ELSE @CreditBatchNum
                    END;

    INSERT  INTO dbo.Orders
            ( Order_No ,
              Product_ID ,
              Price ,
              Quantity ,
              OptQuant ,
              DiscAmount ,
              Name
            )
            SELECT  OrderNo ,
                    389 ,
                    AccSettlement ,
                    1 ,
                    0 ,
                    0 ,
                    'Payment against order ' + CAST(OrderNo AS VARCHAR(Max))
                    + ' in ACH Settlement ' + CAST(Btach AS VARCHAR(Max))
            FROM    #OrderNoSettlement;

	SELECT @AccountCount = @AccountCount + COUNT(OrderNo) FROM #OrderNoSettlement

-- due to potential large updates blocking table orderNo, we insert into a temporary table in order to process by small packets
    INSERT  INTO #OrderNoToProcess
            ( OrderNo ,
              Processed ,
              AdminCreditText ,
              Status
            )
            SELECT  PUB.Order_No ,
                    CONVERT(TINYINT, 0) Processed ,
                    AdminCreditText = 'ACH Batch '
                    + CAST(SUB.Btach AS VARCHAR(Max)) + ' on Credit Memo '
                    + CAST(SUB.OrderNo AS VARCHAR(Max)) ,
                    Status = CAST(SUB.OrderNo AS VARCHAR(Max))
            FROM    dbo.Order_No PUB
                    JOIN #OrderNoSettlement SUB ON PUB.Account_ID = SUB.AccountId
            WHERE   PUB.Filled = 1
                    AND PUB.Process = 1
                    AND PUB.Void = 0
                    AND PUB.Paid = 0
                    AND PUB.OrderType_ID IN ( 1, 2, 3, 8, 22, 21, 28, 31, 34, 40,
                                          46, 49, 51, 54, 57, 62,  68,75, 35)
                    AND PUB.DateDue >= @DateDue AND PUB.DateDue < DATEADD(DAY,1,@DateDue)

-----credit card ----- MR20230329

	INSERT INTO #OrderNoToProcessBeforeHandsetCheck
	(
	    OrderNo,
	    Processed,
	    AdminCreditText,
	    Status,
	    OrderLinkingID
	)

            SELECT  DISTINCT PUB.Order_No ,
                    CONVERT(TINYINT, 0) Processed ,
                    AdminCreditText = 'ACH Batch '
                    + CAST(SUB.Btach AS VARCHAR(Max)) + ' on Credit Memo '
                    + CAST(SUB.OrderNo AS VARCHAR(Max)) ,
                    Status = CAST(SUB.OrderNo AS VARCHAR(Max)),
					link.OrderNoLinkingId
            FROM    dbo.Order_No PUB
                    JOIN #OrderNoSettlement SUB ON PUB.Account_ID = SUB.AccountId
					JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON PUB.Order_No = o1.Order_No
						AND o1.product_ID = 15693		--Purchase Credit Card
					JOIN orders.tblOrderLinking AS link ON link.OrderNo = PUB.Order_No
            WHERE   PUB.Filled = 1
                    AND PUB.Process = 1
                    AND PUB.Void = 0
                    AND PUB.Paid = 0
                    AND PUB.OrderType_ID IN (77)
                    AND PUB.DateDue >= @DateDue AND PUB.DateDue < DATEADD(DAY,1,@DateDue)

-----refund credit card ----- MR20230329

	INSERT INTO #OrderNoToProcessBeforeHandsetCheck
	(
	    OrderNo,
	    Processed,
	    AdminCreditText,
	    Status,
	    OrderLinkingID
	)

            SELECT DISTINCT PUB.Order_No ,
                    CONVERT(TINYINT, 0) Processed ,
                    AdminCreditText = 'ACH Batch '
                    + CAST(SUB.Btach AS VARCHAR(Max)) + ' on Credit Memo '
                    + CAST(SUB.OrderNo AS VARCHAR(Max)) ,
                    Status = CAST(SUB.OrderNo AS VARCHAR(Max)),
					link.OrderNoLinkingId
            FROM    dbo.Order_No PUB
                    JOIN #OrderNoSettlement SUB ON PUB.Account_ID = SUB.AccountId
					JOIN dbo.Orders o1 WITH ( READUNCOMMITTED ) ON PUB.Order_No = o1.Order_No
						AND o1.product_ID = 15693		--Purchase Credit Card
					JOIN orders.tblOrderLinking AS link ON link.OrderNo = PUB.Order_No
					JOIN orders.tblOrderLinking AS CreditCard ON CreditCard.OrderNoLinkingId = link.OrderNoLinkingId
						AND CreditCard.OrderLinkingTypeId = 1 --FundingSource
					JOIN dbo.order_no AS o2  WITH ( READUNCOMMITTED ) ON o2.Order_No = CreditCard.OrderNo
						AND o2.Filled = 1
						AND o2.Void = 0
						AND o2.Process = 1
						AND o2.OrderType_ID IN (77) --original purchase credit card
            WHERE   PUB.Filled = 1
                    AND PUB.Process = 1
                    AND PUB.Void = 0
                    AND PUB.Paid = 0
                    AND PUB.OrderType_ID IN (78) --refund
                    AND PUB.DateDue >= @DateDue AND PUB.DateDue < DATEADD(DAY,1,@DateDue)

--this section added to check the linked handset for both order type 78 and 77 rather than just 77. MR20231004
    INSERT  INTO #OrderNoToProcess
            ( OrderNo ,
              Processed ,
              AdminCreditText ,
              Status
            )
			SELECT DISTINCT p.OrderNo,
                            p.Processed,
                            p.AdminCreditText,
                            p.Status
			FROM #OrderNoToProcessBeforeHandsetCheck AS p
			WHERE EXISTS(SELECT 1 FROM Orders.tblOrderLinking AS link
							JOIN dbo.order_no AS o2  WITH ( READUNCOMMITTED )
								ON o2.Order_No = link.OrderNo
									AND o2.Filled = 1
									AND o2.Void = 0
									AND o2.Process = 1
									AND o2.OrderType_ID IN (49, 57)
						WHERE p.OrderLinkingID = link.OrderNoLinkingId
							AND link.OrderLinkingTypeId = 2) --checkout


-- ZA 20221018
			INSERT  INTO #OrderNoToProcess
            ( OrderNo ,
              Processed ,
              AdminCreditText ,
              Status
            )
            SELECT  PUB.Order_No ,
                    CONVERT(TINYINT, 0) Processed ,
                    AdminCreditText = 'ACH Batch '
                    + CAST(SUB.Btach AS VARCHAR(Max)) + ' on Credit Memo '
                    + CAST(SUB.OrderNo AS VARCHAR(Max)) ,
                    Status = CAST(SUB.OrderNo AS VARCHAR(Max))
            FROM    dbo.Order_No PUB
                    JOIN #OrderNoSettlement SUB ON PUB.Account_ID = SUB.AccountId
					JOIN dbo.Order_No PUB2 ON PUB.AuthNumber = CAST(PUB2.Order_No AS NVARCHAR(15))
					AND PUB2.Filled = 1 AND PUB2.Process = 1 AND PUB2.Void = 0
            WHERE   PUB.Filled = 1
                    AND PUB.Process = 1
                    AND PUB.Void = 0
                    AND PUB.Paid = 0
                    AND PUB.OrderType_ID IN (59,71)
                    AND PUB.DateDue >= @DateDue AND PUB.DateDue < DATEADD(DAY,1,@DateDue)


					--AND (DateOrdered < '2017-01-17 14:15' OR DateOrdered > '2017-01-17 16:00')


    WHILE EXISTS ( SELECT TOP 1
                            OrderNo
                   FROM     #OrderNoToProcess
                   WHERE    Processed = 0 )
        BEGIN

            UPDATE TOP ( 300 )
                    PUB
            SET     Processed = 1
            FROM    #OrderNoToProcess PUB
            WHERE   Processed = 0;

            UPDATE  PUB
            SET     Paid = 1 ,
                    Status = SUB.Status ,
                    AdminCreditText = SUB.AdminCreditText ,
                    Admin_Updated = GETDATE() ,
                    Admin_Name = @AdminName ,
                    InvoiceNum = @DebitBatchNum
            FROM    dbo.Order_No PUB
                    JOIN #OrderNoToProcess SUB ON PUB.Order_No = SUB.OrderNo
            WHERE   SUB.Processed = 1;

            UPDATE TOP ( 300 )
                    PUB
            SET     Processed = 2
            FROM    #OrderNoToProcess PUB
            WHERE   Processed = 1;
        END;

    UPDATE  PUB
    SET     AvailableTotalCreditLimit_Amt = CASE WHEN SUB.AvailableTotalCreditLimit_Amt
                                                      + SUB.AchTotal > SUB.ApprovedTotalCreditLimit_Amt
                                                 THEN SUB.ApprovedTotalCreditLimit_Amt
                                                 ELSE SUB.AvailableTotalCreditLimit_Amt
                                                      + SUB.AchTotal
                                            END
    FROM    dbo.Account PUB
            JOIN #AccountFinal SUB ON PUB.Account_ID = SUB.AccountId
    WHERE   PUB.AccountType_ID <> 11;

EXEC OrderManagment.P_OrderManagment_ProcessUnpaidOrder

    EXEC AutomatedClearingHouse.P_ACH_RunACHParentPostpaidMerchantPayment @DateDue = @DateDue, -- datetime
        @AdminName = @AdminName, -- varchar(50)
        @CreditBatchNum = @CreditBatchNum, -- int
        @IP = @IP, -- varchar(25)
        @DebitBatchNum = @DebitBatchNum; -- int

    EXEC AutomatedClearingHouse.[P_ACH_RunACHParentPrepaidMerchantPayment] @DateDue = @DateDue, -- datetime
        @AdminName = @AdminName, -- varchar(50)
        @CreditBatchNum = @CreditBatchNum, -- int
        @IP = @IP, -- varchar(25)
        @DebitBatchNum = @DebitBatchNum; -- int


    DROP TABLE #TmpOrderNo;
    DROP TABLE #TmpOrderNoFilled;
    DROP TABLE #Orders;
    DROP TABLE #Account;
    DROP TABLE #OrderNoSettlement;
    DROP TABLE #OrderNoToProcess;
	DROP TABLE #OrderNoToProcessBeforeHandsetCheck;
	DROP TABLE #OrdersPreHandsetCheck;
