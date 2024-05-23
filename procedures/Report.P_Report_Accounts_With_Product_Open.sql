--liquibase formatted sql

--changeset Nicolas Griesdorn f17cbfb6 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2017-06-22
--             :
-- Description : Report to pull accounts that have VZW Products
-- LZ20190125  : Abed requested to show all address info
--       Usage :
--  MR20190115 : Added User ID 225057 (Christine) to access this report
-- KMH20210305 : Added User ID 264154 (Dylan) to access this report per Abed's request
-- KMH20210406 : Added account ID look up, columns FederalTaxID, StateTaxID, UserID,
--             : username, account create date, locationid.
--			   : Added my userID (227824) for testing
-- KMH20211001 : Removed User ID 225057 (Christine) report access
--             : Added LEFT JOIN Security.tblPiiMapping and case statements for
--             : FederalTaxID for Token X masking in final select
-- KMH20211006 : Added cast for Security.tblPiiMapping join
-- =============================================
ALTER PROC [Report].[P_Report_Accounts_With_Product_Open]
    (
        @Carrier NVARCHAR(MAX)
        , @productType NVARCHAR(MAX)
        , @account_id NVARCHAR(MAX)
        , @SessionUserID INT
    )
AS


BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF (ISNULL(@SessionUserID, 0) NOT IN (264154, 159497, 227824, 1160, 343854)) --Restrict to Account 2 --Dylan Wethey and Abed and Loulwa
        BEGIN
            SELECT 'This report is highly restricted! Please contact Abed for access approval.' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@Carrier, '') = '' OR ISNULL(@productType, '') = '')
        BEGIN
            SELECT 'All information must be entered' AS [Error Message];
            RETURN;
        END;


    IF OBJECT_ID('tempdb..#ListOfCarriers') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfCarriers;
        END;

    CREATE TABLE #ListOfCarriers
    (CarrierId INT);
    INSERT INTO #ListOfCarriers
    (CarrierId)
    SELECT ID
    FROM dbo.fnSplitter(@Carrier);


    IF OBJECT_ID('tempdb..#ListOfProductType') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfProductType;
        END;

    CREATE TABLE #ListOfProductType
    (productTypeID INT);
    INSERT INTO #ListOfProductType
    (productTypeID)
    SELECT ID
    FROM dbo.fnSplitter(@productType);



    IF OBJECT_ID('tempdb..#TmpAccount') IS NOT NULL						--KMH20210406
        BEGIN
            DROP TABLE #TmpAccount;
        END;

    CREATE TABLE #TmpAccount (Account_Id INT);

    IF (ISNULL(@account_id, '') = '')
        BEGIN
            INSERT INTO #TmpAccount
            EXEC [Account].[P_Account_GetAccountList]
                @AccountID = 2,              -- int
                @UserID = 1,                          -- int
                @AccountTypeID = '0,2,4,5,6,7,8,11',             -- varchar(50)
                @AccountStatusID = '0,1,2,3,4,5,6,7', -- varchar(50)
                @Simplified = 1;                      -- bit
        END
    ELSE
        BEGIN
            INSERT INTO #TmpAccount
            (Account_ID)
            SELECT ID
            FROM dbo.fnSplitter(@account_id);
        END;



    IF OBJECT_ID('tempdb..#ProductAccountList') IS NOT NULL
        BEGIN
            DROP TABLE #ProductAccountList;
        END;

    SELECT DISTINCT
        a.Account_ID
    INTO #ProductAccountList
    FROM #TmpAccount AS ta
    JOIN dbo.Account AS a
        ON a.Account_ID = ta.Account_Id
    JOIN dbo.DiscountClass_Products AS dcp
        ON dcp.DiscountClass_ID = a.DiscountClass_ID
    LEFT JOIN dbo.Account_Products_Discount AS apd
        ON
            apd.Account_ID = a.Account_ID
            AND a.DiscountClass_ID = dcp.DiscountClass_ID
    JOIN dbo.Products AS p
        ON
            p.Product_ID = apd.Product_ID
            AND p.NotSold = 0
            AND p.Display = 1
    JOIN #ListOfProductType AS lpt
        ON ISNULL(p.Product_Type, 0) = lpt.productTypeID
    JOIN Products.tblProductCarrierMapping AS pcm
        ON p.Product_ID = pcm.ProductId
    JOIN #ListOfCarriers AS lc
        ON lc.CarrierId = pcm.CarrierId
    WHERE
        dcp.ApprovedToSell_Flg = 1
        AND ISNULL(apd.ApprovedToSell_Flg, dcp.ApprovedToSell_Flg) = 1;




    --------THIS IS ORIGINAL
    --WITH CTE
    --AS (SELECT DISTINCT
    --           a.Account_ID
    --    FROM dbo.Account                            a
    --        JOIN dbo.DiscountClass_Products         dcp
    --             ON dcp.DiscountClass_ID        = a.DiscountClass_ID
    --        LEFT JOIN dbo.Account_Products_Discount apd
    --                  ON apd.Account_ID         = a.Account_ID
    --                     AND a.DiscountClass_ID = dcp.DiscountClass_ID
    --        JOIN dbo.Products                       p
    --             ON p.Product_ID                = apd.Product_ID
    --                AND p.NotSold               = 0
    --                AND p.Display               = 1
    --        JOIN #ListOfProductType                 lpt
    --             ON ISNULL(p.Product_Type, 0)   = lpt.productTypeID
    --        JOIN Products.tblProductCarrierMapping  pcm
    --             ON p.Product_ID                = pcm.ProductId
    --        JOIN #ListOfCarriers                    lc
    --             ON lc.CarrierId                = pcm.CarrierId
    --    WHERE dcp.ApprovedToSell_Flg                                     = 1
    --          AND ISNULL(apd.ApprovedToSell_Flg, dcp.ApprovedToSell_Flg) = 1)
    SELECT DISTINCT
        a.Account_ID
        , a.Account_Name
        , ati.AccountType_Desc
        , asi.AccountStatus_Desc
        , pa.Account_ID AS [DirectMA]
        , pa.Account_Name AS [DirectMAname]
        , a2.Account_ID AS [TopMA]
        , a2.Account_Name AS [TopMAname]
        , COALESCE(piim.Token, a.FederalTaxID) AS FederalTaxID
        , a.StateSalesTaxID
        , a.User_ID
        , u.UserName
        , a.Create_Dtm
        , alm.LocationID
        , c.Address1 AS [Shipping Address1]
        , c.Address2 AS [Shipping Address2]
        , c.City AS [Shipping City]
        , c.State AS [Shipping State]
        , c.Zip AS [Shipping Zip]
        , c.Phone AS [Shipping Phone]
        , c.Email AS [Shipping Email]
        , c.FirstName AS [Shipping FirstName]
        , c.LastName AS [Shipping LastName]
        , c3.Address1 AS [Contact Address1]
        , c3.Address2 AS [Contact Address2]
        , c3.City AS [Contact City]
        , c3.State AS [Contact State]
        , c3.Zip AS [Contact Zip]
        , c3.Phone AS [Contact Phone]
        , c3.Email AS [Contact Email]
        , c3.FirstName AS [Contact FirstName]
        , c3.LastName AS [Contact LastName]
        , c2.Address1 AS [Billing Address1]
        , c2.Address2 AS [Billing Address2]
        , c2.City AS [Billing City]
        , c2.State AS [Billing State]
        , c2.Zip AS [Billing Zip]
        , c2.Phone AS [Billing Phone]
        , c2.Email AS [Billing Email]
        , c2.FirstName AS [Billing FirstName]
        , c2.LastName AS [Billing LastName]
    FROM #ProductAccountList AS t
    JOIN dbo.Account AS a
        ON a.Account_ID = t.Account_ID
    JOIN dbo.Account AS pa
        ON a.ParentAccount_Account_ID = pa.Account_ID
    LEFT JOIN dbo.Customers AS c
        ON a.ShipTo = c.Customer_ID
    LEFT JOIN dbo.Customers AS c2
        ON c2.Customer_ID = a.Customer_ID
    LEFT JOIN dbo.Customers AS c3
        ON c3.Customer_ID = a.Contact_ID
    LEFT JOIN users AS u
        ON u.User_ID = a.User_ID
    LEFT JOIN Account.tblAccountLocationMapping AS alm
        ON alm.Account_ID = a.Account_ID
    JOIN dbo.AccountType_ID AS ati
        ON ati.AccountType_ID = a.AccountType_ID
    JOIN dbo.AccountStatus_ID AS asi
        ON asi.AccountStatus_ID = a.AccountStatus_ID
    JOIN dbo.Account AS a2
        ON ISNULL(dbo.fn_GetTopParent_NotTcetra_h(a.Hierarchy), 2) = a2.Account_ID
    LEFT JOIN security.tblPiiMapping AS piim									-- KMH20211001
        ON CAST(PIIM.[PiiMappingId] AS NVARCHAR(10)) = a.FederalTaxID
    ;


END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber
        , ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
