--liquibase formatted sql

--changeset MHoward:0D5556 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/*=====================================================================================================
            : 
     Author : Brandon Stahl
            : 
    Created : 2019-01-22
            : 
Description : This Sproc reconciles TracFone RTR confirmations and compares them  
            : against T-Cetra orders to preemptively catch bill discrepancies.  
            : 
 BS20180122 : Calculation for Simple $100 Promo based on pre-rebate billing
            :
      Usage : EXEC [Report].[P_Report_Accounting_TracFoneRTR_ConfirmationRecon]
            : 
 MR20190802 : Updated mapping to inclue the simple mobile exception. 
			  : Added an error status to check if anything other than RTRs ever get mapped in here.
			  :
 MR20190917 : Added a void column and status.
			  :
 MR20190918 : Added three new "insert into" cases
			  :
 MR20190919 : Adjusted the inserts to only insert if not exists already.
			  :
 MR20191505 : Removed the "Where Rnum = 1" condition for the "Duplicate" status.
			  : Changed the Duplicate status to be "Not in TF Bill OR Duplicate" to reflect the other option.
			  :
 MR20200317 : Added VendorDiscrepancy table inserts. Added Username. Cast REDACTDATE to DATE at the end results.

 MR20200318 : Changed the invoice date to be the load date rather than the react date

 MR20200401 : Changed the discrepancy amount insert and the notes column insert.

 MH20200723 : Changed length of Name on #TCetraOrders from 100 to 255 to match max Name length on dbo.Orders

 MR20210326 : Added eight new "INSERT INTO #TCetraOrders" sections. Mostly looking up voided orders and CellDay_History orders to reduce "Not Founds"
			  : Added a "DELETE from #TracfoneBill" after each insert into #TCetraOrders rather than using a "WHERE NOT EXISTS" each time. (And added table #Bill for the end) (Improved performance by about 3 minutes)
			  :	Added "DISTINCT" to #Results
			  : Changed the insert into accounting discrepancies from <> 'Success' to <> 'Found'

 MH20211108 : Changed TCetra cost calculation since Discount Class 10 does not reflect our actual cost.
				Removed $0 'Add a line' product that was causing duplicates
				Added additional check for duplicates

 MH20211123 : Changed product ID 14801 discount from 10% to 10.5% per email from Tracfone

 MH20220120 : Update to hard-coded 10% product list and excluded 10650 from multi-line calculation
			  : Changed Discrepancy amount calculation

 MH20220201 : Changed TCetra cost calculation for Multi month plans to handle case where first month is discounted
 MH20220201 : Fixed typo with cost check (0.1 vs .01)
 MH20220201 : Added additional check match by RTR_remote trans ID and Phone number
 MH20220201 : Moved Add a line exclusion to each Insert
 LUX20220314: Removed index to improve performance
 
 MH20230808 : Added check to make sure we are not billed for RTRs we have refunded to the dealer
		    : Changed mapping to new logic

 MH20240215 : Removed ParentItemID filter to exclude spiffs to accommidate Activation Fee

===================================================================================================*/
-- noqa: enable=all
CREATE OR ALTER PROC [Report].[P_Report_Accounting_TracFoneRTR_ConfirmationRecon]
AS
BEGIN
    SET NOCOUNT ON;

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @Delimiter NCHAR(1) = N'|';

    BEGIN TRY
        IF OBJECT_ID('tempdb..#TracFoneBill') IS NOT NULL
            BEGIN
                DROP TABLE #TracFoneBill;
            END;

        CREATE TABLE #TracFoneBill
        (
            Rnum INT IDENTITY (1, 1) PRIMARY KEY CLUSTERED,
            RTR_Rnum INT NULL,
            ITEM VARCHAR(20),
            [DESCRIPTION] VARCHAR(100),
            PRODUCT VARCHAR(20),
            SMP VARCHAR(20),
            BILLED DECIMAL(5, 2),
            REDACTDATE DATETIME,
            TF_MIN VARCHAR(20),
            RTR_REMOTE_TRANS_ID VARCHAR(100),
            RTR_TRANS_TYPE VARCHAR(20),
            INVOICE_NO INT,
            RETAILER VARCHAR(20),
            DISCOUNT_CODE VARCHAR(20),
            DISCOUNT_AMOUNT DECIMAL(5, 2),
            BILL_ITEM_NUMBER VARCHAR(20),
            LOAD_DATE DATETIME,
            OriginalBillQty INT,
            UserName VARCHAR(50)
        );

        CREATE NONCLUSTERED INDEX IX_Rnum_RTR_TRANS_TYPE ON #TracFoneBill (ITEM) INCLUDE (Rnum, RTR_REMOTE_TRANS_ID);
        IF OBJECT_ID('tempdb..#AddonTypes') IS NOT NULL
            BEGIN
                DROP TABLE #AddonTypes;
            END;

        SELECT
            af.AddonID,
            af.AddonTypeName
        INTO #AddonTypes
        FROM dbo.tblAddonFamily AS af
        WHERE
            af.AddonTypeName IN ('PhoneNumberType', 'ReturnPhoneType', 'BillItemNumberType');

        IF OBJECT_ID('tempdb..#file') IS NOT NULL
            BEGIN
                DROP TABLE #file;
            END;

        SELECT
            T.Chr1 AS [ITEM],
            T.Chr2 AS [DESCRIPTION],
            T.Chr3 AS [PRODUCT],
            T.Chr4 AS [SMP],
            CAST(REPLACE(T.Chr5, '$', '') AS DECIMAL(5, 2)) AS [BILLED],
            CAST(T.Chr6 AS DATE) AS [REDACTDATE],
            T.Chr7 AS [TF_MIN],
            REPLACE(T.Chr8, '''', '') AS [RTR_REMOTE_TRANS_ID],
            T.Chr9 AS [RTR_TRANS_TYPE],
            T.Chr10 AS [INVOICE_NO],
            T.Chr11 AS [RETAILER],
            T.Chr12 AS [DISCOUNT_CODE],
            CAST(
                CASE
                    WHEN ISNUMERIC(T.Chr13) = 1
                        THEN CAST(T.Chr13 AS DECIMAL(5, 2))
                    ELSE 0
                END AS DECIMAL(5, 2)
            ) AS [DISCOUNT_AMOUNT],
            T.Chr14 AS [BillItemNumber],
            CAST(T.Chr15 AS DATE) AS [LOAD_DATE],
            REPLACE(REPLACE(T.Chr16, CHAR(10), ''), CHAR(13), '') AS UserName
        INTO #file
        FROM CellDayTemp.Recon.tblPlainText AS A
        --FROM ##tblPlainText AS A							--Testing
        CROSS APPLY dbo.SplitText(A.PlainText, @Delimiter, '"') AS T
        WHERE
            ISDATE(T.Chr6) = 1;

        INSERT INTO #TracFoneBill
        (
            ITEM,
            DESCRIPTION,
            PRODUCT,
            SMP,
            BILLED,
            REDACTDATE,
            TF_MIN,
            RTR_REMOTE_TRANS_ID,
            RTR_TRANS_TYPE,
            INVOICE_NO,
            RETAILER,
            DISCOUNT_CODE,
            DISCOUNT_AMOUNT,
            BILL_ITEM_NUMBER,
            LOAD_DATE,
            OriginalBillQty,
            UserName
        )
        SELECT
            '9015' AS [Product_ID],
            'Simple Mobile RTR Family Plan' AS [DESCRIPTION],
            t.PRODUCT,
            od.Order_No AS [SMP],
            SUM(CAST(t.BILLED AS DECIMAL(5, 2))) AS [Billed],
            t.REDACTDATE,
            oia1.AddonsValue AS [TF_MIN],
            t.RTR_REMOTE_TRANS_ID,
            t.RTR_TRANS_TYPE,
            t.INVOICE_NO,
            t.RETAILER,
            'Family Plan' AS [DISCOUNT_CODE],
            CAST(0.00 AS DECIMAL(5, 2)) AS [DISCOUNT_AMOUNT],
            0 AS [BILL_ITEM_NUMBER],
            t.LOAD_DATE,
            COUNT(1) AS [OriginalBillQty],
            t.UserName
        FROM
            #file AS t
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.AddonsValue = t.BillItemNumber
        JOIN dbo.tblOrderItemAddons AS oia1
            ON oia.OrderID = oia1.OrderID
        JOIN #AddonTypes AS ty
            ON ty.AddonID = oia1.AddonsID AND ty.AddonTypeName = 'PhoneNumberType'
        JOIN dbo.Orders AS od
            ON
                od.ID = oia.OrderID
                AND od.Product_ID = 9015
                AND od.Order_No = IIF(ISNUMERIC(t.RTR_REMOTE_TRANS_ID) = 1, TRY_CAST(t.RTR_REMOTE_TRANS_ID AS BIGINT), -1)
        GROUP BY
            t.PRODUCT,
            od.Order_No,
            t.REDACTDATE,
            oia1.AddonsValue,
            t.RTR_REMOTE_TRANS_ID,
            t.RTR_TRANS_TYPE,
            t.INVOICE_NO,
            t.RETAILER,
            t.LOAD_DATE,
            t.UserName;

        INSERT INTO #TracFoneBill
        (
            ITEM,
            DESCRIPTION,
            PRODUCT,
            SMP,
            BILLED,
            REDACTDATE,
            TF_MIN,
            RTR_REMOTE_TRANS_ID,
            RTR_TRANS_TYPE,
            INVOICE_NO,
            RETAILER,
            DISCOUNT_CODE,
            DISCOUNT_AMOUNT,
            BILL_ITEM_NUMBER,
            LOAD_DATE,
            OriginalBillQty,
            UserName
        )
        SELECT
            f.ITEM,
            f.DESCRIPTION,
            f.PRODUCT,
            f.SMP,
            f.BILLED,
            f.REDACTDATE,
            f.TF_MIN,
            f.RTR_REMOTE_TRANS_ID,
            f.RTR_TRANS_TYPE,
            f.INVOICE_NO,
            f.RETAILER,
            f.DISCOUNT_CODE,
            f.DISCOUNT_AMOUNT,
            f.BillItemNumber,
            f.LOAD_DATE,
            1 AS OriginalBillQty,
            f.UserName
        FROM
            #file AS f
        WHERE
            NOT EXISTS
            (
                SELECT
                    1
                FROM #TracFoneBill AS t
                WHERE f.RTR_REMOTE_TRANS_ID = t.RTR_REMOTE_TRANS_ID
            );

        IF OBJECT_ID('tempdb..#Bill') IS NOT NULL --MR20210326
            BEGIN
                DROP TABLE #Bill;
            END;

        SELECT
            tb.Rnum,
            tb.RTR_Rnum,
            tb.ITEM,
            tb.DESCRIPTION,
            tb.PRODUCT,
            tb.SMP,
            tb.BILLED,
            tb.REDACTDATE,
            tb.TF_MIN,
            tb.RTR_REMOTE_TRANS_ID,
            tb.RTR_TRANS_TYPE,
            tb.INVOICE_NO,
            tb.RETAILER,
            tb.DISCOUNT_CODE,
            tb.DISCOUNT_AMOUNT,
            tb.BILL_ITEM_NUMBER,
            tb.LOAD_DATE,
            tb.OriginalBillQty,
            tb.UserName
        INTO #Bill --to be used in the final #Results
        FROM #TracFoneBill AS tb;

        IF OBJECT_ID('tempdb..#TCetraOrders') IS NOT NULL
            BEGIN
                DROP TABLE #TCetraOrders;
            END;

        CREATE TABLE #TCetraOrders
        (
            Rnum INT,
            Order_No INT,
            DateFilled DATETIME,
            Product_ID INT,
            Product_Type VARCHAR(50),
            [Name] VARCHAR(255), --MH20200723
            Price DECIMAL(9, 2),
            SKU VARCHAR(100),
            Filled BIT,
            Void BIT, --MR20190917
            ID INT,
            [Status] VARCHAR(20),
            RTR_Remote_trans_ID VARCHAR(100)
        );

        CREATE NONCLUSTERED INDEX IX_Rnum ON #TCetraOrders (Rnum);

        INSERT INTO #TCetraOrders --MH20220201
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN dbo.tblOrderItemAddons AS oia2
            ON o.ID = oia2.OrderID AND oia2.AddonsID IN (8, 27)
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        WHERE
            tb.RTR_TRANS_TYPE IN ('ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE')
            --AND ISNULL(o.ParentItemID, 0) = 0				--MH20240215 (removed)
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (1, 9, 22, 23)
            AND RIGHT(tb.TF_MIN, 4) = RIGHT(oia2.AddonsValue, 4)
            AND RTR_REMOTE_TRANS_ID NOT IN -- noqa: RF02
            (
                SELECT
                    RTR_REMOTE_TRANS_ID
                FROM
                    #TracFoneBill
                GROUP BY
                    RTR_REMOTE_TRANS_ID,
                    RIGHT(TF_MIN, 4)
                HAVING
                    COUNT(RIGHT(TF_MIN, 4)) > 1
            )
            AND NOT
            (
                o.Product_ID IN (8387, 8553) --Add a line
                AND o.Price = 0
            );

        DELETE
        tf ----MR20210326 added these after each insert into #TCetraOrders 
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        JOIN dbo.tblOrderItemAddons AS oia1 --WITH (INDEX(IX_tblOrderItemAddons_AddonsValue)) -- LUX-20220314 Removed to improve performance
            ON oia1.OrderID = o.ID AND oia1.AddonsValue = tb.BILL_ITEM_NUMBER
        JOIN #AddonTypes AS ats
            ON ats.AddonID = oia1.AddonsID
        WHERE
            tb.RTR_TRANS_TYPE IN ('ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE')
            --AND ISNULL(o.ParentItemID, 0) = 0						--MH20240215 (removed)
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (1, 9, 22, 23);

        DELETE
        tf ----MR20210326 added these after each insert into #TCetraOrders 
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20190918
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND p.Product_Type IN (
                    1, 3
                ) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        JOIN dbo.tblOrderItemAddons AS oia1 WITH (INDEX (IX_tblOrderItemAddons_AddonsValue))
            ON
                oia1.OrderID = o.ID
                AND oia1.AddonsValue = tb.TF_MIN --MR20190918
        JOIN #AddonTypes AS ats
            ON ats.AddonID = oia1.AddonsID
        WHERE
            tb.RTR_TRANS_TYPE IN (
                'ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE'
            )
            --AND ISNULL(o.ParentItemID, 0) = 0			--MH20240215 (removed)
            AND n.Void = 0
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        --AND NOT EXISTS								--Removed these in each INSERT MR20210326
        --   (
        --       SELECT 1 FROM #TCetraOrders AS t WHERE t.Rnum = tb.Rnum
        --   )
        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            #TracFoneBill AS tb
        JOIN dbo.Order_No AS n
            ON n.Order_No = tb.RTR_REMOTE_TRANS_ID
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID
        WHERE
            tb.ITEM = '9015'
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (
                1, 9
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        ----this section new MR20190918
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            #TracFoneBill AS tb
        JOIN dbo.Order_No AS n
            ON CAST(n.Order_No AS VARCHAR(75)) = tb.RTR_REMOTE_TRANS_ID
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND p.Product_Type IN (
                    1, 3
                )
        WHERE
            tb.ITEM <> '9015'
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (
                22, 23
            );

        --AND ISNULL(o.ParentItemID,0) = 0;			--MH20240215 (removed)
        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = o.SKU
        WHERE
            tb.RTR_TRANS_TYPE = 'ADD'
            AND n.Void = 0 --MR20190917
            AND o.Product_ID NOT IN (
                391, 392
            )
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = o.ID
        JOIN #TracFoneBill AS tb
            ON
                tb.RTR_REMOTE_TRANS_ID = CAST(n.Order_No AS VARCHAR(200))
                AND oia.AddonsValue = tb.BILL_ITEM_NUMBER
        WHERE
            tb.RTR_TRANS_TYPE IN (
                'REDEMPTION', 'REACTIVATION'
            )
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void, --MR20190917
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void, --MR20190917
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = CAST(CONCAT(n.Order_No, o.ID) AS VARCHAR(50))
        WHERE
            tb.RTR_TRANS_TYPE = 'ACT'
            AND n.Void = 0 --MR20190917
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: checking for voided match ON tb.RTR_REMOTE_TRANS_ID = CAST(CONCAT(n.Order_No, o.ID) AS VARCHAR(50))
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = CAST(CONCAT(n.Order_No, o.ID) AS VARCHAR(50))
        WHERE
            tb.RTR_TRANS_TYPE = 'ADD'
            AND n.Void = 1
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: checking for voided match ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue AND phone number
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            MIN(n.Order_No) AS Order_No,
            MIN(n.DateFilled) AS DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            MIN(o.sku) AS SKU,
            n.Filled,
            n.Void,
            MIN(o.ID) AS ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND p.Product_Type IN (
                    1, 3
                ) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        JOIN dbo.tblOrderItemAddons AS oia1
            ON oia1.OrderID = o.ID AND oia1.AddonsValue = tb.TF_MIN
        JOIN #AddonTypes AS ats
            ON ats.AddonID = oia1.AddonsID
        WHERE
            tb.RTR_TRANS_TYPE IN (
                'ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE'
            )
            --AND ISNULL(o.ParentItemID, 0) = 0			--MH20240215 (removed)
            AND n.Void = 1
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            )
        GROUP BY
            tb.Rnum,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            n.Filled,
            n.Void,
            tb.RTR_REMOTE_TRANS_ID;

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --------second void section-----------------
        --this section new MR20210326: checking for voided match ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue and service tag matches product
        IF OBJECT_ID('tempdb..#PreAdditionalVoids') IS NOT NULL
            BEGIN
                DROP TABLE #PreAdditionalVoids;
            END;

        SELECT DISTINCT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.DiscAmount,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        INTO #PREAdditionalVoids
        FROM dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND p.Product_Type IN (
                    1, 3
                ) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        JOIN CarrierSetup.tblCommonVendorProductMapping AS pm
            ON pm.Service_Tag = tb.ITEM AND pm.Product_ID = o.Product_ID
        WHERE
            tb.RTR_TRANS_TYPE IN (
                'ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE'
            )
            --AND ISNULL(o.ParentItemID, 0) = 0			--MH20240215 (removed)
            AND n.Void = 1
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        IF OBJECT_ID('tempdb..#AdditionalVoids') IS NOT NULL
            BEGIN
                DROP TABLE #AdditionalVoids;
            END;

        SELECT
            pav.Rnum,
            ROW_NUMBER() OVER (
                PARTITION BY
                pav.Rnum
                ORDER BY
                    pav.Price,
                    pav.ID
            ) AS Price_Rnum,
            pav.Order_No,
            pav.DateFilled,
            pav.Product_ID,
            pav.Product_Type,
            pav.Name,
            pav.Price,
            pav.DiscAmount,
            pav.SKU,
            pav.Filled,
            pav.Void,
            pav.ID,
            pav.Status
        INTO #AdditionalVoids
        FROM #PREAdditionalVoids AS pav;

        IF OBJECT_ID('tempdb..#VoidTracFoneBill') IS NOT NULL
            BEGIN
                DROP TABLE #VoidTracFoneBill;
            END;

        SELECT
            tf.Rnum,
            ROW_NUMBER() OVER (
                PARTITION BY
                tf.RTR_REMOTE_TRANS_ID
                ORDER BY
                    tf.BILLED
            ) AS RTR_Rnum,
            tf.ITEM,
            tf.DESCRIPTION,
            tf.PRODUCT,
            tf.SMP,
            tf.BILLED,
            tf.REDACTDATE,
            tf.TF_MIN,
            tf.RTR_REMOTE_TRANS_ID,
            tf.RTR_TRANS_TYPE,
            tf.INVOICE_NO,
            tf.RETAILER,
            tf.DISCOUNT_CODE,
            tf.DISCOUNT_AMOUNT,
            tf.BILL_ITEM_NUMBER,
            tf.LOAD_DATE,
            tf.OriginalBillQty,
            tf.UserName
        INTO #VoidTracFoneBill
        FROM #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #AdditionalVoids AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            av.Rnum,
            av.Order_No,
            av.DateFilled,
            av.Product_ID,
            av.Product_Type,
            av.Name,
            av.Price,
            av.SKU,
            av.Filled,
            av.Void,
            av.ID,
            av.Status,
            tf.RTR_REMOTE_TRANS_ID
        FROM
            #AdditionalVoids AS av
        JOIN #VoidTracFoneBill AS tf
            ON av.Rnum = tf.Rnum AND tf.RTR_Rnum = av.Price_Rnum;

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        ------------third void section-------------
        --this section new MR20210326: checking for a voided match  ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        IF OBJECT_ID('tempdb..#ThirdPreAdditionalVoids') IS NOT NULL
            BEGIN
                DROP TABLE #ThirdPreAdditionalVoids;
            END;

        SELECT DISTINCT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.DiscAmount,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        INTO #ThirdPreAdditionalVoids
        FROM dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        WHERE
            tb.RTR_TRANS_TYPE IN ('ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE')
            --AND ISNULL(o.ParentItemID, 0) = 0			--MH20240215 (removed)
            AND n.Void = 1
            AND n.OrderType_ID IN (1, 9, 22, 23)
            AND NOT EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS t2
                WHERE
                    t2.ID = o.ID
            );

        IF OBJECT_ID('tempdb..#ThirdAdditionalVoids') IS NOT NULL
            BEGIN
                DROP TABLE #ThirdAdditionalVoids;
            END;

        SELECT
            pav.Rnum,
            ROW_NUMBER() OVER (
                PARTITION BY
                pav.Rnum
                ORDER BY
                    pav.Price,
                    pav.ID
            ) AS Price_Rnum,
            pav.Order_No,
            pav.DateFilled,
            pav.Product_ID,
            pav.Product_Type,
            pav.Name,
            pav.Price,
            pav.DiscAmount,
            pav.SKU,
            pav.Filled,
            pav.Void,
            pav.ID,
            pav.Status
        INTO #ThirdAdditionalVoids
        FROM #ThirdPreAdditionalVoids AS pav;

        IF OBJECT_ID('tempdb..#ThirdVoidTracFoneBill') IS NOT NULL
            BEGIN
                DROP TABLE #ThirdVoidTracFoneBill;
            END;

        SELECT
            tf.Rnum,
            ROW_NUMBER() OVER (
                PARTITION BY
                tf.RTR_REMOTE_TRANS_ID ORDER BY tf.BILLED
            ) AS RTR_Rnum,
            tf.ITEM,
            tf.DESCRIPTION,
            tf.PRODUCT,
            tf.SMP,
            tf.BILLED,
            tf.REDACTDATE,
            tf.TF_MIN,
            tf.RTR_REMOTE_TRANS_ID,
            tf.RTR_TRANS_TYPE,
            tf.INVOICE_NO,
            tf.RETAILER,
            tf.DISCOUNT_CODE,
            tf.DISCOUNT_AMOUNT,
            tf.BILL_ITEM_NUMBER,
            tf.LOAD_DATE,
            tf.OriginalBillQty,
            tf.UserName
        INTO #ThirdVoidTracFoneBill
        FROM #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #ThirdAdditionalVoids AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            av.Rnum,
            av.Order_No,
            av.DateFilled,
            av.Product_ID,
            av.Product_Type,
            av.Name,
            av.Price,
            av.SKU,
            av.Filled,
            av.Void,
            av.ID,
            'ThirdFound' AS [Status],
            tf.RTR_REMOTE_TRANS_ID
        FROM
            #ThirdAdditionalVoids AS av
        JOIN #ThirdVoidTracFoneBill AS tf
            ON av.Rnum = tf.Rnum AND tf.RTR_Rnum = av.Price_Rnum;

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: checking for match on order number and date filled
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            #TracFoneBill AS tb
        JOIN dbo.Order_No AS n
            ON tb.RTR_REMOTE_TRANS_ID = CAST(n.Order_No AS VARCHAR(50)) AND CAST(n.DateFilled AS DATE) = CAST(tb.REDACTDATE AS DATE)
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        WHERE
            n.OrderType_ID IN (1, 9, 22, 23)
            --AND ISNULL(o.ParentItemID,0) = 0			--MH20240215 (removed)
            AND NOT EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS t2
                WHERE
                    t2.ID = o.ID
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: checking history for a match on both RTR_REMOTE_TRANS_ID in addons value and Phone Number
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            CellDay_History.dbo.Order_No AS n
        JOIN CellDay_History.dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND p.Product_Type IN (
                    1, 3
                ) --MH20240215
        JOIN CellDay_History.dbo.tblOrderItemAddons AS oia
            ON oia.Order_No = o.Order_No
        JOIN #TracFoneBill AS tb
            ON tb.RTR_REMOTE_TRANS_ID = oia.AddonsValue
        JOIN CellDay_History.dbo.tblOrderItemAddons AS oia1
            ON oia1.Order_No = o.Order_No AND oia1.AddonsValue = tb.TF_MIN
        JOIN #AddonTypes AS ats
            ON ats.AddonID = oia1.AddonsID AND ats.AddonTypeName = 'PhoneNumberType'
        WHERE
            tb.RTR_TRANS_TYPE IN (
                'ACTIVATION', 'REACTIVATION', 'REDEMPTION', 'ADD_TO_RESERVE'
            )
            --AND ISNULL(o.ParentItemID, 0) = 0			--MH20240215 (removed)
            AND n.Void = 0
            AND n.OrderType_ID IN (
                1, 9, 22, 23
            );

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: checking history for a match on phone number and date
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            #TracFoneBill AS tb
        JOIN CellDay_History.dbo.tblOrderItemAddons AS oia
            ON tb.TF_MIN = oia.AddonsValue
        JOIN #AddonTypes AS af
            ON af.AddonID = oia.AddonsID AND af.AddonTypeName = 'PhoneNumberType'
        JOIN CellDay_History.dbo.orders AS o
            ON o.id = oia.OrderID
        --AND ISNULL(o.ParentItemID,0) = 0			--MH20240215 (removed)
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        JOIN CellDay_History.dbo.Order_No AS n
            ON
                n.Order_No = oia.Order_No
                AND CAST(n.DateFilled AS DATE) = tb.REDACTDATE
                AND n.Filled = 1
                AND n.void = 0
                AND n.Process = 1
                AND n.OrderType_ID IN (1, 9, 22, 23);

        DELETE
        tf
        FROM
            #TracFoneBill AS tf
        WHERE
            EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS tc
                WHERE
                    tc.Rnum = tf.Rnum
            );

        --this section new MR20210326: looking for bill item number
        INSERT INTO #TCetraOrders
        (
            Rnum,
            Order_No,
            DateFilled,
            Product_ID,
            Product_Type,
            [Name],
            Price,
            SKU,
            Filled,
            Void,
            ID,
            [Status],
            RTR_Remote_trans_ID
        )
        SELECT
            tb.Rnum,
            n.Order_No,
            n.DateFilled,
            o.Product_ID,
            p.Product_Type,
            o.Name,
            o.Price,
            o.SKU,
            n.Filled,
            n.Void,
            o.ID,
            'Found' AS [Status],
            tb.RTR_REMOTE_TRANS_ID
        FROM
            #TracFoneBill AS tb
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.AddonsValue = tb.BILL_ITEM_NUMBER AND oia.AddonsID = 196 --BillItemNumberType
        JOIN dbo.Orders AS o
            ON o.ID = oia.OrderID
        --AND ISNULL(o.ParentItemID,0) = 0			--MH20240215 (removed)
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3) --MH20240215
        JOIN dbo.Order_No AS n
            ON n.Order_No = o.Order_No AND n.OrderType_ID IN (1, 9, 22, 23) AND n.Void = 0
        WHERE
            ISNULL(tb.BILL_ITEM_NUMBER, '') <> ''
            AND NOT EXISTS
            (
                SELECT
                    1
                FROM
                    #TCetraOrders AS t2
                WHERE
                    t2.ID = o.ID
            );

        ----------------------------------------

        --IF OBJECT_ID('tempdb..#logData') IS NOT NULL		--MH20230808 replaced with new mapping logic below
        --BEGIN
        --    DROP TABLE #logData;
        --END;

        --SELECT ot.Order_No,
        --       ot.Product_ID,
        --       MIN(lvpm.ID) AS [MinLogId]
        --INTO #logData
        --FROM #TCetraOrders ot
        --    JOIN [Logs].[VendorProductMapping] lvpm
        --        ON CAST(lvpm.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --           AND ot.DateFilled < lvpm.LogDate
        --           AND NOT EXISTS
        --                   (
        --                       SELECT 1
        --                       FROM dbo.Order_Activation_User_Lock oaul
        --                       WHERE oaul.Order_No = ot.Order_No
        --                   )
        --           AND lvpm.RegiondIdBefore = CASE
        --                                          WHEN EXISTS
        --                                               (
        --                                                   SELECT 1
        --                                                   FROM dbo.tblOrderItemAddons oia
        --                                                   WHERE oia.OrderID = ot.ID
        --                                                         AND oia.AddonsID = 26
        --                                               )
        --                                               AND EXISTS
        --                                                   (
        --                                                       SELECT 1
        --                                                       FROM [Logs].[VendorProductMapping] lvpm2
        --                                                       WHERE lvpm2.RegiondIdBefore = 4
        --                                                             AND ot.DateFilled < lvpm2.LogDate
        --                                                             AND lvpm2.VendorSkuBefore IS NOT NULL
        --                                                             AND CAST(lvpm2.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --                                                   ) THEN
        --                                              4
        --                                          ELSE
        --                                              1
        --                                      END
        --GROUP BY ot.Order_No,
        --         ot.Product_ID;

        --IF OBJECT_ID('tempdb..#VendorData') IS NOT NULL
        --BEGIN
        --    DROP TABLE #VendorData;
        --END;

        --SELECT DISTINCT
        --       ot.Order_No,
        --       ot.Product_ID,
        --       vpm.Region_ID,
        --       CASE
        --           WHEN EXISTS
        --                (
        --                    SELECT 1
        --                    FROM dbo.Order_Activation_User_Lock oaul
        --                    WHERE oaul.Order_No = ot.Order_No
        --                ) THEN
        --               ISNULL(p.Vendor1_SKU, ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID))
        --           ELSE
        --               ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID)
        --       END AS [VendorSku],
        --       vpm.Vendor_SKU AS [vpmVendor_SKU]
        --INTO #VendorData
        --FROM #TCetraOrders ot
        --    JOIN dbo.Products AS p
        --        ON p.Product_ID = ot.Product_ID
        --    JOIN dbo.Vendor_Product_Mapping vpm
        --        ON CAST(vpm.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --           AND vpm.Region_ID = CASE
        --                                   WHEN EXISTS
        --                                        (
        --                                            SELECT 1
        --                                            FROM dbo.tblOrderItemAddons oia
        --                                            WHERE oia.OrderID = ot.ID
        --                                                  AND oia.AddonsID = 26
        --                                        )
        --                                        AND EXISTS
        --                                            (
        --                                                SELECT 1
        --                                                FROM dbo.Vendor_Product_Mapping vpm2
        --                                                WHERE vpm2.Region_ID = 4
        --                                                      AND vpm2.Vendor_SKU IS NOT NULL
        --                                                      AND CAST(vpm2.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --                                            ) THEN
        --                                       4
        --                                   ELSE
        --                                       1
        --                               END
        --    JOIN [Products].[tblProductCarrierMapping] AS pcm
        --        ON CAST(pcm.[ProductId] AS VARCHAR(7)) = ot.Product_ID --MR20190802
        --           AND pcm.CarrierId <> 4;

        --INSERT INTO #VendorData
        --(
        --    Order_No,
        --    Product_ID,
        --    VendorSku,
        --    vpmVendor_SKU
        --) --MR20190802

        --SELECT DISTINCT
        --       ot.Order_No,
        --       ot.Product_ID,
        --       ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID) AS [VendorSku],
        --       vpm.Vendor_SKU AS [vpmVendor_SKU]
        --FROM #TCetraOrders ot
        --    JOIN dbo.Vendor_Product_Mapping vpm
        --        ON CAST(vpm.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --           AND vpm.Region_ID = CASE
        --                                   WHEN EXISTS
        --                                        (
        --                                            SELECT 1
        --                                            FROM dbo.tblOrderItemAddons oia
        --                                            WHERE oia.OrderID = ot.ID
        --                                                  AND oia.AddonsID = 26
        --                                        )
        --                                        AND EXISTS
        --                                            (
        --                                                SELECT 1
        --                                                FROM dbo.Vendor_Product_Mapping vpm2
        --                                                WHERE vpm2.Region_ID = 4
        --                                                      AND vpm2.Vendor_SKU IS NOT NULL
        --                                                      AND CAST(vpm2.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --                                            ) THEN
        --                                       4
        --                                   ELSE
        --                                       1
        --                               END
        --    JOIN [Products].[tblProductCarrierMapping] AS pcm
        --        ON CAST(pcm.[ProductId] AS VARCHAR(7)) = ot.Product_ID
        --           AND pcm.CarrierId = 4;
        DELETE
        o --MH20211108 Total Wireless Add a line											
        FROM
            #TCetraOrders AS o
        WHERE
            o.Product_ID IN (
                8387, 8553
            )
            AND o.Price = 0;

        IF OBJECT_ID('tempdb..#Duplicates') IS NOT NULL
            BEGIN
                DROP TABLE #Duplicates;
            END;

        SELECT
            tcf.Rnum,
            COUNT(1) AS Qty
        INTO #Duplicates
        FROM #TCetraOrders AS tcf
        GROUP BY
            tcf.Rnum
        HAVING
            COUNT(1) > 1;

        IF OBJECT_ID('tempdb..#Margins') IS NOT NULL --MH20211108
            BEGIN
                DROP TABLE #Margins;
            END;

        CREATE TABLE #Margins
        (
            ID INT,
            Dealer_Margin DECIMAL(9, 2),
            MA_Margin DECIMAL(9, 2),
            TSP_Margin DECIMAL(9, 2),
            Addtnl_Margin DECIMAL(9, 2)
        );

        INSERT INTO #Margins
        VALUES
        (
            1, 8.5, 1, 1, 0
        ),
        (
            2, 8, 1, 1, 0
        ),
        (
            3, 12, 1, 1, 1
        );

        --MH20230808 checking for items we are billed for that we refunded
        IF OBJECT_ID('tempdb..#Refunded') IS NOT NULL
            BEGIN
                DROP TABLE #Refunded;
            END;

        SELECT
            t.Order_No,
            n.Order_No AS RefundOrder_No
        INTO #Refunded
        FROM dbo.Order_No AS n
        JOIN #TCetraOrders AS t
            ON n.AuthNumber = t.Order_No
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        WHERE
            n.OrderType_ID IN (
                1, 9
            )
            AND n.Filled = 1
            AND n.Process = 1
            AND n.Void = 0
            AND o.Price < 0
            AND t.Product_ID = o.Product_ID;

        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        SELECT DISTINCT --MR20210326
            tb.ITEM,
            tb.[DESCRIPTION],
            tb.PRODUCT,
            tb.SMP,
            tb.BILLED,
            tb.REDACTDATE,
            tb.TF_MIN,
            tb.RTR_REMOTE_TRANS_ID,
            tb.RTR_TRANS_TYPE,
            tb.INVOICE_NO,
            tb.RETAILER,
            tb.DISCOUNT_CODE,
            tb.DISCOUNT_AMOUNT,
            tb.BILL_ITEM_NUMBER,
            tb.LOAD_DATE,
            t.Order_No,
            t.DateFilled,
            --CASE
            --    WHEN ISNULL(t.Product_Type, 0) = 3 THEN
            --        ISNULL(
            --                  ISNULL(CAST(tvpm.VendorSkuBefore AS VARCHAR(10)), CAST(vd.VendorSku AS VARCHAR(10))),
            --                  t.Product_ID
            --              )
            --    ELSE
            --        t.Product_ID
            --END AS [Product_ID],
            p.Product_ID,
            t.Name,
            CASE -- BS20180122
                WHEN t.Product_ID IN (9997, 10054)
                    THEN 40.00
                ELSE t.Price
            END AS Price,
            CAST(ROUND(
                CASE --MH20220201
                    WHEN ISNULL(rm.MonthNumber, 1) = 1
                        THEN t.Price - (t.Price * ((m.Dealer_Margin + m.MA_Margin + m.TSP_Margin + m.Addtnl_Margin) / 100))
                    WHEN ISNULL(rm.MonthNumber, 1) > 1
                        THEN
                            ((p2.Retail_Price / rm.MonthNumber) - (p2.Retail_Price - t.Price))
                            - (
                                ((p2.Retail_Price / rm.MonthNumber) - (p2.Retail_Price - t.Price))
                                * ((m.Dealer_Margin + m.MA_Margin + m.TSP_Margin + m.Addtnl_Margin) / 100)
                            )
                END, 2
            ) AS DECIMAL(6, 2)) AS [AmountDue],
            tb.OriginalBillQty,
            CASE
                WHEN t.Status IS NULL
                    THEN 'Not Found'
                WHEN rf.Order_No IS NOT NULL
                    THEN 'Check if Dealer refunded'
                WHEN
                    EXISTS
                    (
                        SELECT
                            1
                        FROM
                            #Duplicates AS d
                        WHERE
                            d.Rnum = tb.Rnum
                    )
                    THEN 'Not in TF Bill OR Duplicated'
                WHEN t.Void = 1
                    THEN 'Void'
                WHEN t.Filled = 0
                    THEN 'Pending'
                WHEN
                    ABS(tb.BILLED - CAST(ROUND(
                        CASE --MH20220201
                            WHEN ISNULL(rm.MonthNumber, 1) = 1
                                THEN t.Price - (t.Price * ((m.Dealer_Margin + m.MA_Margin + m.TSP_Margin + m.Addtnl_Margin) / 100))
                            WHEN ISNULL(rm.MonthNumber, 1) > 1
                                THEN ((p2.Retail_Price / rm.MonthNumber) - (p2.Retail_Price - t.Price)) - (((p2.Retail_Price / rm.MonthNumber) - (p2.Retail_Price - t.Price)) * ((m.Dealer_Margin + m.MA_Margin + m.TSP_Margin + m.Addtnl_Margin) / 100)) -- noqa: LT05
                        END, 2
                    ) AS DECIMAL(6, 2))) > 0.01
                    THEN 'Incorrectly Billed'
                ELSE t.Status
            END AS [Status],
            tb.UserName,
            ROW_NUMBER() OVER (
                PARTITION BY
                tb.Rnum
                ORDER BY
                    tb.Rnum ASC,
                    t.Order_No DESC
            ) AS RowNumber --MH20211108
        INTO #Results
        FROM #Bill AS tb
        LEFT JOIN #TCetraOrders AS t
            ON t.Rnum = tb.Rnum
        --         LEFT JOIN #VendorData AS vd			--MH20230808
        --             ON vd.Order_No = t.Order_No
        --                AND vd.Product_ID = t.Product_ID
        --         LEFT JOIN #logData l
        --             ON l.Order_No = t.Order_No
        --                AND l.Product_ID = t.Product_ID
        --         LEFT JOIN [Logs].[VendorProductMapping] tvpm
        --             ON tvpm.ID = l.[MinLogId]
        --         --LEFT JOIN [dbo].[tblShadowProductLinking] AS tsp			--MH20211108
        --         --    ON tsp.ProductID = t.Product_ID
        --         --LEFT JOIN dbo.DiscountClass_Products AS dcp
        --         --    ON dcp.Product_ID = tsp.[ShadowProductID]
        --         --     AND dcp.DiscountClass_ID = 10
        --LEFT JOIN dbo.Products AS p										--MH20211108
        --	ON p.Product_ID = 
        --					   CASE
        --						   WHEN ISNULL(t.Product_Type, 0) = 3 THEN
        --							   ISNULL(
        --										 ISNULL(CAST(tvpm.VendorSkuBefore AS VARCHAR(10)), CAST(vd.VendorSku AS VARCHAR(10))),
        --										 t.Product_ID
        --									 )
        --						   ELSE
        --							   t.Product_ID
        --					    END
        LEFT JOIN Orders.tblOrderVendorDetails AS vd --MH20230808
            ON t.ID = vd.OrderId AND ISNULL(t.Product_Type, 0) = 3
        LEFT JOIN dbo.Vendor_Product_Mapping AS vpm
            ON t.Product_ID = vpm.Product_ID AND vpm.Region_ID = 1 AND ISNULL(t.Product_Type, 0) = 3
        LEFT JOIN dbo.Products AS p
            ON CASE
                WHEN ISNULL(t.Product_Type, 0) = 3
                    THEN ISNULL(ISNULL(vd.FundingProductID, vpm.Vendor_SKU), t.Product_ID)
                ELSE t.Product_ID
            END = p.Product_ID
        JOIN #Margins AS m
            ON
                m.ID =
                CASE
                    WHEN
                        p.Product_ID IN (
                            9540, 9541, 9542, 9543, 9544
                        )
                        THEN 3
                    WHEN
                        p.Product_ID IN (
                            9545, 10647, 10648, 10649, 9548, 9540, 9546
                        ) --MH20211123 removed 14801, MH20220120
                        THEN 2
                    ELSE 1
                END
        LEFT JOIN Products.tblXRefilProductMapping AS rm --MH20211108 Multi month plans
            ON t.Product_ID = rm.OrigProductID AND rm.MonthNumber > 1 AND rm.IndIsActive = 1 --MH20220120
        LEFT JOIN dbo.Products AS p2
            ON rm.OrigProductID = p2.Product_ID
        LEFT JOIN #Refunded AS rf --MH20230808
            ON t.Order_No = rf.Order_No;

        -----------------
        UPDATE r
        SET
            r.Status = 'Mapping Error'
        FROM
            #Results AS r
        JOIN dbo.Products AS p
            ON r.Product_ID = p.Product_ID
        WHERE
            ISNULL(p.Product_Type, 0) <> 1;

        UPDATE
        r --MH20211108 Fixes status for Multi-line plans
        SET
            r.Status = 'Found'
        FROM
            #Results AS r
        WHERE
            r.RTR_REMOTE_TRANS_ID IN
            (
                SELECT DISTINCT -- noqa: AM01
                    r2.RTR_REMOTE_TRANS_ID
                FROM
                    #Results AS r2
                GROUP BY
                    r2.RTR_REMOTE_TRANS_ID
                HAVING
                    COUNT(r2.RTR_REMOTE_TRANS_ID) > 1
                    AND SUM(r2.BILLED) = SUM(r2.AmountDue)
            );

        UPDATE
        r --MH20211108 Single bill item still on more than one order
        SET
            r.Status = 'Not in TF Bill OR Duplicated'
        FROM
            #Results AS r
        WHERE
            r.SMP IN
            (
                SELECT DISTINCT
                    SMP
                FROM
                    #Results
                WHERE
                    RowNumber > 1
            );

        TRUNCATE TABLE CellDayTemp.Recon.tblTracfoneRTRConfirmationRecon;

        INSERT INTO CellDayTemp.Recon.tblTracfoneRTRConfirmationRecon
        (
            ITEM,
            DESCRIPTION,
            PRODUCT,
            SMP,
            BILLED,
            REDACTDATE,
            TF_MIN,
            RTR_REMOTE_TRANS_ID,
            RTR_TRANS_TYPE,
            INVOICE_NO,
            RETAILER,
            DISCOUNT_CODE,
            DISCOUNT_AMOUNT,
            BILL_ITEM_NUMBER,
            LOAD_DATE,
            Order_No,
            DateFilled,
            Product_ID,
            Name,
            Price,
            AmountDue,
            OriginalBillQty,
            Status
        )
        SELECT
            r.ITEM,
            r.DESCRIPTION,
            r.PRODUCT,
            r.SMP,
            r.BILLED,
            r.REDACTDATE,
            r.TF_MIN,
            r.RTR_REMOTE_TRANS_ID,
            r.RTR_TRANS_TYPE,
            r.INVOICE_NO,
            r.RETAILER,
            r.DISCOUNT_CODE,
            r.DISCOUNT_AMOUNT,
            r.BILL_ITEM_NUMBER,
            r.LOAD_DATE,
            r.Order_No,
            r.DateFilled,
            r.Product_ID,
            r.Name,
            r.Price,
            r.AmountDue,
            r.OriginalBillQty,
            r.Status
        FROM
            #Results AS r;

        INSERT INTO Cellday_Accounting.acct.VendorInvoice --MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )
        SELECT DISTINCT
            CONCAT(YEAR(CAST(r.LOAD_DATE AS DATE)), MONTH(CAST(r.LOAD_DATE AS DATE)), DAY(CAST(r.LOAD_DATE AS DATE)), 'Tracfone') AS InvoiceNo,
            r.LOAD_DATE AS InvoiceDate,
            8 AS Process_ID -- Tracfone
        FROM
            #Results AS r
        WHERE
            r.Status <> 'Found'
            AND NOT EXISTS
            (   --MH20220222
                SELECT
                    vi.InvoiceDate
                FROM
                    Cellday_Accounting.Acct.VendorInvoice AS vi
                WHERE
                    vi.InvoiceDate = r.LOAD_DATE
                    AND vi.Process_Id = 8
            );

        INSERT INTO Cellday_Accounting.acct.VendorDiscrepancies --MR20190711
        (
            Process_Id,
            DateCreated,
            UserCreated,
            Discrepancy_ID,
            Notes,
            DiscrepancyAmt,
            TransactionID,
            Order_No,
            VendorInvoice_ID
        )
        SELECT
            8 AS process_ID, --Tracfone
            GETDATE() AS DateCreated,
            r.UserName AS UserCreated,
            CASE
                WHEN r.Status = 'Incorrectly Billed'
                    THEN 15
                WHEN r.Status = 'Pending'
                    THEN 10
                WHEN r.Status = 'Not Found'
                    THEN 14
                WHEN r.Status = 'Void'
                    THEN 9
                WHEN r.Status = 'Not in TF Bill OR Duplicated'
                    THEN 19
                ELSE 11
            END AS Discrepancy_ID,
            CONCAT(r.BILLED, ' was billed ', r.AmountDue, ' was due.') AS Notes,
            CASE
                WHEN r.Status IN ('Incorrectly Billed') --MH20220120
                    THEN (r.BILLED - r.AmountDue)
                ELSE r.BILLED
            END AS DiscrepancyAmt,
            r.RTR_REMOTE_TRANS_ID AS TransactionID,
            r.Order_No AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            ON vi.InvoiceDate = r.LOAD_DATE AND vi.Process_Id = 8 --Tracfone
        WHERE r.Status <> 'Found'; --MR20210326
    END TRY
    BEGIN CATCH
    ; THROW;
    END CATCH;
END
-- noqa: disable=all
/